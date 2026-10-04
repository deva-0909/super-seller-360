"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { mapStatement, parseCsv, type CsvLine, type DateFormat } from "@/lib/bank-csv";

const btn = "h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";

export function Toolbar({ accountId, canWrite, canSync }: { accountId: string; canWrite: boolean; canSync: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [csvOpen, setCsvOpen] = useState(false);
  const [fmt, setFmt] = useState<DateFormat>("DD/MM/YYYY");
  const [parsed, setParsed] = useState<{ lines: CsvLine[]; skipped: number; problem?: string; columns: Record<string, string>; name: string } | null>(null);

  async function run(label: string, fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>, say: (d: Record<string, number>) => string) {
    setBusy(label); setMsg(null); setErr(null);
    const { data, error } = await fn();
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(say((data ?? {}) as Record<string, number>));
    router.refresh();
  }

  async function onFile(f: File | undefined) {
    if (!f) return;
    const text = await f.text();
    setParsed({ ...mapStatement(parseCsv(text), fmt), name: f.name });
    setFileText(text);
  }
  const [fileText, setFileText] = useState("");
  function reparse(next: DateFormat) {
    setFmt(next);
    if (fileText) setParsed({ ...mapStatement(parseCsv(fileText), next), name: parsed?.name ?? "" });
  }

  async function importCsv() {
    if (!parsed || parsed.lines.length === 0) return;
    setBusy("import"); setMsg(null); setErr(null);
    const tot = { imported: 0, duplicates_skipped: 0, rejected: 0, matched_to_books: 0, suggested: 0, excluded: 0, booked_by_rules: 0, sent_for_review: 0 } as Record<string, number>;
    for (let i = 0; i < parsed.lines.length; i += 1000) {
      const { data, error } = await supabase.rpc("ingest_bank_statement", { p_bank_account_id: accountId, p_lines: parsed.lines.slice(i, i + 1000), p_source: "csv" });
      if (error) { setBusy(null); setErr(friendlyError(error.message)); return; }
      for (const k of Object.keys(tot)) tot[k] += Number((data as Record<string, number>)[k] ?? 0);
    }
    setBusy(null);
    setMsg(`Imported ${tot.imported} new lines (${tot.duplicates_skipped} were already there). ${tot.matched_to_books} matched existing entries, ${tot.suggested} need your confirmation, ${tot.booked_by_rules} booked by rules, ${tot.sent_for_review} drafts for review${tot.excluded ? `, ${tot.excluded} excluded` : ""}.`);
    setParsed(null); setCsvOpen(false); setFileText("");
    router.refresh();
  }

  async function sync() {
    setBusy("sync"); setMsg(null); setErr(null);
    const { data, error } = await supabase.functions.invoke("bank-statement-sync", { body: { bank_account_id: accountId, action: "pull" } });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    const d = (data ?? {}) as Record<string, number | string>;
    if (d.error) { setErr(String(d.error)); return; }
    setMsg(`Pulled from the bank: ${d.imported ?? 0} new lines, ${d.duplicates_skipped ?? 0} already there.`);
    router.refresh();
  }

  if (!canWrite) return <p className="text-xs text-ink-muted">Your role can view reconciliation but not change it.</p>;

  return (
    <div>
      <div className="flex flex-wrap items-start gap-3">
        <button className={btn} disabled={!!busy} onClick={() => run("match", () => supabase.rpc("run_bank_reconciliation", { p_bank_account_id: accountId }), (r) => `Checked ${r.checked}: ${r.reconciled} matched, ${r.suggested} suggested, ${r.excluded} excluded.`)}>
          {busy === "match" ? "Matching…" : "Match with books"}
        </button>
        <button className={btn} disabled={!!busy} onClick={() => run("rules", () => supabase.rpc("apply_bank_rules", {}), (r) => `Checked ${r.checked}: ${r.posted} booked, ${r.sent_for_review} sent for review.`)}>
          {busy === "rules" ? "Booking…" : "Book the rest with Rule Book"}
        </button>
        <button className={btn} disabled={!!busy} onClick={() => setCsvOpen((o) => !o)}>Import statement (CSV)</button>
        {canSync ? <button className={btn} disabled={!!busy} onClick={sync}>{busy === "sync" ? "Syncing…" : "Sync from bank API"}</button> : null}
      </div>
      {csvOpen ? (
        <div className="mt-3 max-w-2xl border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Bank statement CSV</p>
          <p className="mt-1 text-xs text-ink-muted">Download the statement from your net-banking as CSV. Lines already imported are skipped, so overlapping dates are fine.</p>
          <div className="mt-3 flex flex-wrap items-center gap-3">
            <input type="file" accept=".csv,text/csv,.txt" onChange={(e) => onFile(e.target.files?.[0])} className="text-sm" />
            <label className="flex items-center gap-2 text-xs text-ink-muted">Dates are
              <select className="h-8 border border-line bg-surface px-1 text-xs" value={fmt} onChange={(e) => reparse(e.target.value as DateFormat)}>
                <option value="DD/MM/YYYY">DD/MM/YYYY</option><option value="MM/DD/YYYY">MM/DD/YYYY</option><option value="YYYY-MM-DD">YYYY-MM-DD</option>
              </select>
            </label>
          </div>
          {parsed?.problem ? <p className="mt-3 text-sm text-danger">{parsed.problem}</p> : null}
          {parsed && !parsed.problem ? (
            <div className="mt-3 text-xs text-ink-muted">
              <p>{parsed.lines.length} lines found{parsed.skipped ? `, ${parsed.skipped} rows ignored` : ""}. Reading: date = “{parsed.columns.date}”, narration = “{parsed.columns.description}”, amount = “{parsed.columns.amount}”, balance = “{parsed.columns.balance}”.</p>
              <table className="mt-2 w-full">
                <tbody>
                  {parsed.lines.slice(0, 4).map((l, i) => (
                    <tr key={i} className="border-t border-line"><td className="py-1">{l.date}</td><td className="py-1 text-ink">{l.description.slice(0, 40)}</td><td className="py-1 text-right font-data">{l.type === "credit" ? "+" : "-"}{l.amount.toLocaleString("en-IN")}</td></tr>
                  ))}
                </tbody>
              </table>
              <button className="mt-3 h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50" disabled={!!busy || parsed.lines.length === 0} onClick={importCsv}>
                {busy === "import" ? "Importing…" : `Import ${parsed.lines.length} lines`}
              </button>
            </div>
          ) : null}
        </div>
      ) : null}
      {msg ? <p className="mt-3 text-sm text-success">{msg}</p> : null}
      {err ? <p className="mt-3 text-sm text-danger">{err}</p> : null}
    </div>
  );
}
