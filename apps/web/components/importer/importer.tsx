"use client";

import { useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";
import { KINDS } from "@/lib/importer/kinds";
import { parseFile, type ParseResult } from "@/lib/importer/parse";

type RowResult = { row: number; status: "ok" | "warning" | "error"; action: string | null; message: string | null };
type RunResult = {
  run_id: string | null;
  applied: boolean;
  file_error: string | null;
  rows: RowResult[];
  summary: { total: number; added: number; updated: number; unchanged: number; warnings: number; errors: number };
};

const PILL: Record<string, string> = {
  ok: "text-success bg-success-tint border-success/30",
  warning: "text-warning bg-warning-tint border-warning/30",
  error: "text-danger bg-danger-tint border-danger/30",
};
const LABEL: Record<string, string> = { ok: "OK", warning: "Warning", error: "Error" };
const ACTION: Record<string, string> = { add: "Add", update: "Update", unchanged: "No change", rejected: "Rejected" };

function defaultFinancialYear() {
  const d = new Date();
  const y = d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1;
  return `FY${y}-${String((y + 1) % 100).padStart(2, "0")}`;
}

export function Importer({ kind, channels, defaultFy }: { kind: string; channels?: { channel_id: string; name: string }[]; defaultFy?: string }) {
  const cfg = KINDS[kind];
  const router = useRouter();
  const supabase = createClient();
  const fileRef = useRef<HTMLInputElement>(null);

  const [file, setFile] = useState<File | null>(null);
  const [parsed, setParsed] = useState<ParseResult | null>(null);
  const [preview, setPreview] = useState<RunResult | null>(null);
  const [done, setDone] = useState<RunResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<null | "reading" | "checking" | "importing">(null);
  const [filter, setFilter] = useState<"all" | "error" | "warning">("all");
  const [showAll, setShowAll] = useState(false);
  const [channelId, setChannelId] = useState(channels?.[0]?.channel_id ?? "");
  const [fy, setFy] = useState(defaultFy ?? defaultFinancialYear());

  const options = () => (cfg.option === "channel" ? { channel_id: channelId } : cfg.option === "financial_year" ? { financial_year: fy } : {});

  async function check(f: File, p: ParseResult) {
    setBusy("checking"); setError(null); setPreview(null);
    const { data, error: e } = await supabase.rpc("import_run", { p_kind: kind, p_rows: p.rows, p_apply: false, p_options: options() });
    setBusy(null);
    if (e) { setError(friendlyError(e.message)); return; }
    setPreview(data as unknown as RunResult);
    void f;
  }

  async function onFile(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0];
    if (!f) return;
    setFile(f); setParsed(null); setPreview(null); setDone(null); setError(null); setFilter("all"); setShowAll(false);
    setBusy("reading");
    try {
      const p = await parseFile(cfg, f);
      setBusy(null);
      if (p.missing.length) { setError(`The file has no "${p.missing.join('", "')}" column. Download the template and use its headings.`); setParsed(p); return; }
      if (!p.rows.length) { setError("That file has no rows to import."); return; }
      setParsed(p);
      await check(f, p);
    } catch (err) {
      setBusy(null);
      setError(err instanceof Error ? err.message : "Could not read that file.");
    }
  }

  async function recheck() { if (file && parsed) await check(file, parsed); }

  async function doImport() {
    if (!file || !parsed) return;
    setBusy("importing"); setError(null);
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { setBusy(null); setError("Please sign in again."); return; }
    const safe = file.name.replace(/[^A-Za-z0-9._-]/g, "_");
    const path = `${user.id}/${Date.now()}-${safe}`;
    const up = await supabase.storage.from("imports").upload(path, file, { contentType: file.type || "application/octet-stream" });
    if (up.error) { setBusy(null); setError(`The original file could not be kept, so nothing was imported (${up.error.message}).`); return; }
    const { data, error: e } = await supabase.rpc("import_run", {
      p_kind: kind, p_rows: parsed.rows, p_apply: true, p_options: options(), p_file_name: file.name, p_file_path: path,
    });
    setBusy(null);
    if (e) { setError(friendlyError(e.message)); return; }
    const res = data as unknown as RunResult;
    setDone(res); setPreview(null); setParsed(null); setFile(null);
    if (fileRef.current) fileRef.current.value = "";
    router.refresh();
  }

  function reset() {
    setFile(null); setParsed(null); setPreview(null); setDone(null); setError(null);
    if (fileRef.current) fileRef.current.value = "";
  }

  function downloadIssues(res: RunResult) {
    const lines = ["Row,Result,Message", ...res.rows.filter((r) => r.status !== "ok").map((r) => `${r.row},${LABEL[r.status]},"${(r.message ?? "").replace(/"/g, '""')}"`)];
    const url = URL.createObjectURL(new Blob([lines.join("\n")], { type: "text/csv" }));
    const a = document.createElement("a"); a.href = url; a.download = `${kind}-issues.csv`; a.click(); URL.revokeObjectURL(url);
  }

  const importable = preview ? preview.rows.filter((r) => r.status !== "error" && (r.action === "add" || r.action === "update")).length : 0;
  const rows = preview ? preview.rows.filter((r) => filter === "all" || r.status === filter) : [];
  const shown = showAll ? rows : rows.slice(0, 200);
  const channelMissing = cfg.option === "channel" && !channelId;

  return (
    <div className="mt-6 flex flex-col gap-6">
      <div className="border border-line bg-surface p-5">
        <div className="flex flex-wrap items-center gap-3">
          <a href={`/api/import-template/${kind}`} className="inline-flex h-10 items-center rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken">
            1. Download the Excel template
          </a>
          <span className="text-xs text-ink-muted">Headings, drop-down lists and an example row. You can also upload the portal or Tally file as it is if its headings match.</span>
        </div>

        {cfg.option === "channel" ? (
          <div className="mt-4 flex max-w-sm flex-col gap-1.5">
            <label htmlFor="imp-channel" className="text-sm font-medium text-ink">Channel these orders belong to</label>
            <select id="imp-channel" value={channelId} onChange={(e) => { setChannelId(e.target.value); setPreview(null); }}
              className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent">
              {channels?.map((c) => <option key={c.channel_id} value={c.channel_id}>{c.name}</option>)}
            </select>
          </div>
        ) : null}
        {cfg.option === "financial_year" ? (
          <div className="mt-4 flex max-w-sm flex-col gap-1.5">
            <label htmlFor="imp-fy" className="text-sm font-medium text-ink">Financial year these balances open</label>
            <input id="imp-fy" value={fy} onChange={(e) => { setFy(e.target.value); setPreview(null); }}
              className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent" />
            <p className="text-xs text-ink-muted">For example FY2026-27: balances as on 1 April 2026.</p>
          </div>
        ) : null}

        <div className="mt-4 flex flex-col gap-1.5">
          <label htmlFor="imp-file" className="text-sm font-medium text-ink">2. Upload the file (.xlsx or .csv)</label>
          <input id="imp-file" ref={fileRef} type="file" accept=".xlsx,.csv,.txt" onChange={onFile} disabled={busy !== null || channelMissing}
            className="text-sm text-ink file:mr-3 file:border file:border-line file:bg-surface file:px-3 file:py-1.5 file:text-sm" />
        </div>
        {busy === "reading" ? <p className="mt-3 text-sm text-ink-muted">Reading the file…</p> : null}
        {busy === "checking" ? <p className="mt-3 text-sm text-ink-muted">Checking every row…</p> : null}
        {error ? <p role="alert" className="mt-3 text-sm text-danger">{error}</p> : null}
        {parsed?.ignored.length ? <p className="mt-2 text-xs text-ink-muted">Columns not used by this upload: {parsed.ignored.join(", ")}.</p> : null}
      </div>

      {preview ? (
        <div className="border border-line bg-surface">
          <div className="border-b border-line p-5">
            <h2 className="text-sm font-semibold text-ink">3. Preview. Nothing is saved yet.</h2>
            <p className="mt-1 text-xs text-ink-muted">{file?.name}: {preview.summary.total} row{preview.summary.total === 1 ? "" : "s"}</p>
            <div className="mt-3 flex flex-wrap gap-2 text-xs">
              <span className="rounded-full border border-success/30 bg-success-tint px-2.5 py-0.5 font-semibold text-success">{preview.summary.total - preview.summary.errors - preview.summary.warnings} OK</span>
              <span className="rounded-full border border-warning/30 bg-warning-tint px-2.5 py-0.5 font-semibold text-warning">{preview.summary.warnings} Warning</span>
              <span className="rounded-full border border-danger/30 bg-danger-tint px-2.5 py-0.5 font-semibold text-danger">{preview.summary.errors} Error</span>
              <span className="px-1 py-0.5 text-ink-muted">Will add {preview.summary.added}, update {preview.summary.updated}, leave {preview.summary.unchanged} unchanged</span>
            </div>
            {preview.file_error ? <p role="alert" className="mt-3 border border-danger/30 bg-danger-tint p-3 text-sm text-danger">{preview.file_error}</p> : null}
            <div className="mt-4 flex flex-wrap items-center gap-3">
              <Button onClick={doImport} disabled={busy !== null || importable === 0 || !!preview.file_error} className="w-auto px-4">
                {busy === "importing" ? "Importing…" : preview.summary.errors > 0 && !preview.file_error ? `Import the ${importable} good row${importable === 1 ? "" : "s"}` : `Import ${importable} row${importable === 1 ? "" : "s"}`}
              </Button>
              <Button variant="secondary" onClick={reset} disabled={busy !== null} className="w-auto px-4">Choose another file</Button>
              {preview.summary.errors + preview.summary.warnings > 0 ? (
                <button onClick={() => downloadIssues(preview)} className="text-xs text-accent hover:underline">Download the list of problems</button>
              ) : null}
              <button onClick={recheck} disabled={busy !== null} className="text-xs text-ink-muted hover:text-ink">Check again</button>
            </div>
            {preview.summary.errors > 0 && !preview.file_error ? (
              <p className="mt-2 text-xs text-ink-muted">Rows in error are skipped. Fix them in the file and upload it again: rows already imported will not be duplicated.</p>
            ) : null}
          </div>

          <div className="flex gap-2 border-b border-line px-5 py-2 text-xs">
            {(["all", "error", "warning"] as const).map((f) => (
              <button key={f} onClick={() => setFilter(f)} className={`rounded px-2 py-1 ${filter === f ? "bg-surface-sunken font-semibold text-ink" : "text-ink-muted hover:text-ink"}`}>
                {f === "all" ? "All rows" : f === "error" ? "Errors only" : "Warnings only"}
              </button>
            ))}
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="border-b border-line-strong text-xs text-ink-muted">
                  <th className="px-4 py-2 font-medium">Row</th>
                  <th className="px-4 py-2 font-medium">Result</th>
                  <th className="px-4 py-2 font-medium">What happens</th>
                  <th className="px-4 py-2 font-medium">Why</th>
                </tr>
              </thead>
              <tbody>
                {shown.map((r, i) => (
                  <tr key={`${r.row}-${i}`} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                    <td className="px-4 py-2 font-data text-ink-muted">{r.row || "File"}</td>
                    <td className="px-4 py-2"><span className={`inline-flex rounded-full border px-2.5 py-0.5 text-xs font-semibold ${PILL[r.status]}`}>{LABEL[r.status]}</span></td>
                    <td className="px-4 py-2 text-ink-muted">{r.action ? ACTION[r.action] ?? r.action : ""}</td>
                    <td className="px-4 py-2 text-ink">{r.message}</td>
                  </tr>
                ))}
                {!shown.length ? <tr><td colSpan={4} className="px-4 py-6 text-center text-sm text-ink-muted">Nothing to show here.</td></tr> : null}
              </tbody>
            </table>
          </div>
          {rows.length > shown.length ? (
            <button onClick={() => setShowAll(true)} className="w-full border-t border-line px-4 py-3 text-xs text-accent hover:bg-surface-sunken">Show all {rows.length} rows</button>
          ) : null}
        </div>
      ) : null}

      {done ? (
        <div className="border border-success/30 bg-success-tint p-5 text-sm text-ink">
          <p className="font-semibold text-success">{done.applied ? "Import finished." : "Nothing was imported."}</p>
          {done.applied ? (
            <p className="mt-1">Added {done.summary.added}, updated {done.summary.updated}, unchanged {done.summary.unchanged}, rejected {done.summary.errors}.</p>
          ) : (
            <p className="mt-1 text-danger">{done.file_error}</p>
          )}
          <div className="mt-3 flex flex-wrap gap-4 text-xs">
            <Link href={cfg.backHref} className="text-accent hover:underline">Go to {cfg.backLabel}</Link>
            {done.run_id ? <Link href={`/imports/log/${done.run_id}`} className="text-accent hover:underline">See this import in the log</Link> : null}
            <button onClick={reset} className="text-accent hover:underline">Upload another file</button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
