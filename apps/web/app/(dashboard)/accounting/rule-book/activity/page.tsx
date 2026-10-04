import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { RunButton } from "../review/bulk-actions";

const STATUSES = ["posted", "draft", "ignored", "skipped", "error", "discarded"];
const TONE: Record<string, "success" | "warning" | "danger" | "neutral"> = { posted: "success", draft: "warning", error: "danger", ignored: "neutral", skipped: "neutral", discarded: "neutral" };

export default async function ActivityPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const { status } = await searchParams;
  const supabase = await createClient();
  let q = supabase
    .from("journal_rule_log")
    .select("log_id, rule_code, event_type, status, message, created_at, vouchers(voucher_no)")
    .order("created_at", { ascending: false })
    .limit(200);
  if (status && STATUSES.includes(status)) q = q.eq("status", status);
  const { data } = await q;
  const rows = (data ?? []) as unknown as { log_id: string; rule_code: string | null; event_type: string; status: string; message: string | null; created_at: string; vouchers: { voucher_no: string } | null }[];

  return (
    <div>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex flex-wrap gap-2">
          <Link href="/accounting/rule-book/activity" className={`rounded-full border px-3 py-1 text-xs ${!status ? "border-accent font-semibold text-ink" : "border-line text-ink-muted"}`}>All</Link>
          {STATUSES.map((s) => (
            <Link key={s} href={`/accounting/rule-book/activity?status=${s}`} className={`rounded-full border px-3 py-1 text-xs capitalize ${status === s ? "border-accent font-semibold text-ink" : "border-line text-ink-muted"}`}>{s}</Link>
          ))}
        </div>
        <RunButton fn="run_journal_backfill" label="Post pending entries for existing records" doneText={(r) => `Done: ${Object.entries(r).map(([k, v]) => `${v} ${k}`).join(", ") || "nothing new"}.`} />
      </div>
      <p className="mt-3 text-xs text-ink-muted">Every time the rule book acted on something — or tried and could not — it is written here. A failed event never blocks your warehouse or bank work; fix the rule and press the button on the right.</p>

      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-sm">
          <thead className="bg-surface-sunken text-left text-xs text-ink-muted">
            <tr><th className="px-3 py-2">When</th><th className="px-3 py-2">Event</th><th className="px-3 py-2">Rule</th><th className="px-3 py-2">Result</th><th className="px-3 py-2">Voucher</th><th className="px-3 py-2">Note</th></tr>
          </thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={6} className="px-3 py-6 text-center text-ink-muted">Nothing here yet.</td></tr> : null}
            {rows.map((r) => (
              <tr key={r.log_id} className="border-t border-line align-top">
                <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-muted">{new Date(r.created_at).toLocaleString("en-IN")}</td>
                <td className="px-3 py-2 text-xs text-ink">{r.event_type}</td>
                <td className="px-3 py-2 font-data text-xs text-ink">{r.rule_code ?? "—"}</td>
                <td className="px-3 py-2"><StatusPill status={TONE[r.status] ?? "neutral"}>{r.status}</StatusPill></td>
                <td className="px-3 py-2 font-data text-xs text-ink">{r.vouchers?.voucher_no ?? "—"}</td>
                <td className="px-3 py-2 text-xs text-ink-muted">{r.message}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
