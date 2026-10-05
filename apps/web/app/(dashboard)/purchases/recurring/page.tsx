import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { inr } from "@/lib/report-utils";
import { RecurringActions } from "./actions";
import { RecurringForm } from "./recurring-form";

type Row = {
  recurring_id: string; name: string; frequency: string; next_date: string; end_date: string | null; status: string; runs: number; last_run_date: string | null;
  last_error: string | null; lines: { quantity: number; unit_price: number; gst_rate: number }[]; suppliers: { name: string } | null;
};
const FREQ: Record<string, string> = { monthly: "Every month", quarterly: "Every 3 months", yearly: "Every year" };
const today = () => new Date().toISOString().slice(0, 10);

export default async function RecurringBillsPage() {
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data }, { data: suppliers }, { data: ledgers }] = await Promise.all([
    supabase.from("recurring_bills").select("recurring_id, name, frequency, next_date, end_date, status, runs, last_run_date, last_error, lines, suppliers(name)").order("next_date"),
    supabase.from("suppliers").select("supplier_id, name").eq("status", "active").order("name"),
    supabase.from("ledgers").select("ledger_id, name, nature").eq("status", "active").in("nature", ["expense", "asset"]).order("name"),
  ]);
  const rows = (data ?? []) as unknown as Row[];
  const options = (ledgers ?? []).filter((l) => l.nature === "expense" || l.name === "Inventory - Stock-in-Trade");
  const due = rows.filter((r) => r.status === "active" && r.next_date <= today()).length;
  const amount = (r: Row) => r.lines.reduce((s, l) => s + Number(l.quantity) * Number(l.unit_price) * (1 + Number(l.gst_rate) / 100), 0);

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Recurring bills</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">
        Rent, internet, software and other bills that repeat. When one is due, press the button and it creates a normal <Link href="/purchases/bills" className="text-accent underline">purchase bill</Link> waiting for approval.
        Nothing is posted until a second person approves it.
      </p>
      {canWrite ? <RecurringActions due={due} /> : null}

      <div className="mt-4 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Name</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Repeats</th>
            <th className="px-4 py-3 font-medium">Next bill</th><th className="px-4 py-3 text-right font-medium">About</th><th className="px-4 py-3 font-medium">Status</th><th className="px-4 py-3" />
          </tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.recurring_id} className="border-b border-line/60 align-top">
                <td className="px-4 py-3 text-ink">{r.name}{r.last_error ? <span className="mt-1 block text-xs text-danger">Last attempt failed: {r.last_error}</span> : null}</td>
                <td className="px-4 py-3 text-ink-muted">{r.suppliers?.name ?? "—"}</td>
                <td className="px-4 py-3 text-ink-muted">{FREQ[r.frequency]}{r.end_date ? ` until ${r.end_date}` : ""}</td>
                <td className="px-4 py-3 text-ink">{r.next_date}{r.status === "active" && r.next_date <= today() ? <span className="ml-2 bg-warning-tint px-2 py-0.5 text-xs font-semibold text-warning">Due</span> : null}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(amount(r))}</td>
                <td className="px-4 py-3 text-ink-muted">{r.status === "active" ? "Active" : r.status === "paused" ? "Paused" : "Ended"} · {r.runs} bill{r.runs === 1 ? "" : "s"} made</td>
                <td className="px-4 py-3 text-right">{canWrite ? <RecurringActions id={r.recurring_id} status={r.status} dueNow={r.status === "active" && r.next_date <= today()} /> : null}</td>
              </tr>
            ))}
            {!rows.length ? <tr><td colSpan={7} className="px-4 py-10 text-center text-sm text-ink-muted">No recurring bills yet. Add one below.</td></tr> : null}
          </tbody>
        </table>
      </div>

      {canWrite ? <RecurringForm suppliers={(suppliers ?? []).map((s) => ({ id: s.supplier_id, label: s.name }))} ledgers={options.map((l) => ({ id: l.ledger_id, label: l.name }))} /> : null}
    </div>
  );
}
