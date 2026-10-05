import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { frequencyLabel } from "@/lib/recurring";
import { RunDueButton, ScheduleActions } from "./schedule-actions";

type Entry = { voucher_id: string; voucher_no: string; voucher_date: string; narration: string | null; total_debit: number; source_type: string | null; status: string };
type Rev = { voucher_id: string; status: string; review_note: string | null; score: number };
type Schedule = {
  recurring_id: string; name: string; frequency: string; start_date: string; end_date: string | null; runs: number; next_run_date: string;
  last_run_date: string | null; last_error: string | null; status: string; lines: { ledger_id: string; debit?: number; credit?: number }[];
};

const inr = (n: number) => "₹" + Number(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function reviewPill(voucher: string, r?: string) {
  if (voucher === "cancelled") return <StatusPill status="danger">Rejected</StatusPill>;
  if (voucher === "draft" || r === "held") return <StatusPill status="warning">Waiting for approval</StatusPill>;
  if (r === "pending") return <StatusPill status="warning">To be checked</StatusPill>;
  if (r === "wrong") return <StatusPill status="danger">Needs correction</StatusPill>;
  if (r === "corrected") return <StatusPill status="neutral">Corrected</StatusPill>;
  if (r === "ok" || r === "approved") return <StatusPill status="success">Checked</StatusPill>;
  return <span className="text-xs text-ink-muted">-</span>;
}

export default async function JournalPage({ searchParams }: { searchParams: Promise<{ posted?: string; held?: string; attach?: string }> }) {
  const { posted, held, attach } = await searchParams;
  const supabase = await createClient();
  const [{ data: en }, { data: sc }, { data: canWrite }] = await Promise.all([
    supabase.from("vouchers").select("voucher_id, voucher_no, voucher_date, narration, total_debit, source_type, status, voucher_types!inner(code)")
      .eq("voucher_types.code", "JOURNAL").in("source_type", ["manual", "recurring"]).order("voucher_date", { ascending: false }).order("voucher_no", { ascending: false }).limit(60),
    supabase.from("recurring_journals").select("recurring_id, name, frequency, start_date, end_date, runs, next_run_date, last_run_date, last_error, status, lines").order("status").order("next_run_date"),
    supabase.rpc("has_accounting_write"),
  ]);
  const entries = (en ?? []) as unknown as Entry[];
  const { data: rv } = entries.length ? await supabase.from("journal_review").select("voucher_id, status, review_note, score").in("voucher_id", entries.map((e) => e.voucher_id)) : { data: [] };
  const rev = new Map(((rv ?? []) as Rev[]).map((r) => [r.voucher_id, r]));
  const schedules = (sc ?? []) as unknown as Schedule[];
  const write = canWrite === true;

  return (
    <div className="px-4 md:px-8 py-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-ink">Journal entries</h1>
          <p className="mt-1 text-sm text-ink-muted">Hand-written entries, including ones that repeat on a schedule.</p>
        </div>
        {write ? <Link href="/accounting/journal/new" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold leading-10 text-white shadow-sm hover:bg-accent-hover">+ New journal entry</Link> : null}
      </div>
      {posted ? <p className="mt-4 border border-success/30 bg-success-tint p-3 text-sm text-success">Posted {posted}.</p> : null}
      {held ? <p className="mt-4 border border-warning/30 bg-warning-tint p-3 text-sm text-warning">{held} is saved and waiting for a manager&apos;s approval. It is not in the books yet.</p> : null}
      {attach === "failed" ? <p className="mt-2 border border-warning/30 bg-warning-tint p-3 text-sm text-warning">The entry was posted, but the attachment could not be linked to it. Re-upload it from the entry.</p> : null}

      <section className="mt-8">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 className="text-sm font-semibold text-ink">Recurring entries</h2>
          {write && schedules.length ? <RunDueButton /> : null}
        </div>
        {schedules.length === 0 ? (
          <p className="mt-2 border border-line bg-surface p-4 text-sm text-ink-muted">None yet. Tick “This is a recurring entry” when posting a journal entry.</p>
        ) : (
          <div className="mt-2 border border-line bg-surface">
            {schedules.map((s, i) => {
              const amt = s.lines.reduce((t, l) => t + Number(l.debit ?? 0), 0);
              return (
                <div key={s.recurring_id} className={`flex flex-wrap items-start justify-between gap-3 px-4 py-3 ${i ? "border-t border-line" : ""} ${s.status !== "active" ? "bg-surface-sunken/60" : ""}`}>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-sm font-semibold text-ink">{s.name}</span>
                      <StatusPill status={s.status === "active" ? "success" : s.status === "paused" ? "warning" : "neutral"}>{s.status === "active" ? "Running" : s.status === "paused" ? "Paused" : "Finished"}</StatusPill>
                      <span className="text-xs text-ink-muted">{frequencyLabel(s.frequency)} · {inr(amt)}</span>
                    </div>
                    <p className="mt-1 text-xs text-ink-muted">
                      Started {s.start_date} · {s.runs} posted{s.last_run_date ? ` · last ${s.last_run_date}` : ""}
                      {s.status === "active" ? <> · next <span className="font-semibold text-ink">{s.next_run_date}</span></> : null}
                      {s.end_date ? ` · stops after ${s.end_date}` : ""}
                    </p>
                    {s.last_error && s.status === "active" ? <p className="mt-1 text-xs text-danger">Waiting: {s.last_error}</p> : null}
                  </div>
                  <ScheduleActions id={s.recurring_id} status={s.status} canWrite={write} />
                </div>
              );
            })}
          </div>
        )}
      </section>

      <section className="mt-8">
        <h2 className="text-sm font-semibold text-ink">Recent entries</h2>
        {entries.length === 0 ? <p className="mt-2 text-sm text-ink-muted">No hand-written journal entries yet.</p> : (
          <div className="mt-2 overflow-x-auto border border-line bg-surface">
            <table className="w-full text-sm">
              <thead><tr className="border-b border-line text-left text-xs text-ink-muted"><th className="px-3 py-2">Date</th><th className="px-3 py-2">Entry</th><th className="px-3 py-2">Narration</th><th className="px-3 py-2 text-right">Amount</th><th className="px-3 py-2">Type</th><th className="px-3 py-2">Check</th></tr></thead>
              <tbody>
                {entries.map((e) => (
                  <tr key={e.voucher_id} className="border-b border-line last:border-b-0">
                    <td className="px-3 py-2 font-data">{e.voucher_date}</td>
                    <td className="px-3 py-2 font-data">{e.voucher_no}</td>
                    <td className="px-3 py-2 text-ink-muted">{e.narration}{rev.get(e.voucher_id)?.review_note ? <div className="mt-0.5 text-xs text-warning">Reviewer: {rev.get(e.voucher_id)?.review_note}</div> : null}</td>
                    <td className="px-3 py-2 text-right font-data">{inr(e.total_debit)}</td>
                    <td className="px-3 py-2">{e.source_type === "recurring" ? <StatusPill status="neutral">Recurring</StatusPill> : <StatusPill status="neutral">One-off</StatusPill>}</td>
                    <td className="px-3 py-2">{reviewPill(e.status, rev.get(e.voucher_id)?.status)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
