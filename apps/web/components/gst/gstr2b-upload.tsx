"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { parseGstr2b, type Parsed } from "@/lib/gstr2b-parse";
import { primaryBtn } from "@/components/purchases/bits";

export function Gstr2bUpload({ month, hasUpload }: { month: string; hasUpload: boolean }) {
  const router = useRouter();
  const [file, setFile] = useState<string>("");
  const [parsed, setParsed] = useState<Parsed | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function pick(e: React.ChangeEvent<HTMLInputElement>) {
    setErr(null); setParsed(null);
    const f = e.target.files?.[0];
    if (!f) return;
    if (f.size > 15 * 1024 * 1024) { setErr("The file is too large (limit 15 MB)."); return; }
    setFile(f.name);
    setParsed(parseGstr2b(await f.text(), f.name));
  }

  async function send() {
    if (!parsed || !parsed.rows.length) return;
    if (hasUpload && !window.confirm("A file is already uploaded for this month. Replace it? The earlier upload is kept in history, but any 'accepted' or 'ignored' choices are lost.")) return;
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("import_gstr2b", { p_period: month, p_file_name: file, p_rows: parsed.rows });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setParsed(null); setFile("");
    router.refresh();
  }

  const mismatch = parsed?.period && parsed.period !== month;
  return (
    <div className="mt-4 border border-line bg-surface p-4">
      <p className="text-sm font-medium text-ink">Upload the GSTR-2B for {month}</p>
      <p className="mt-1 text-xs text-ink-muted">On the GST portal: Returns, GSTR-2B, Download, JSON. A CSV with these columns also works: Supplier GSTIN, Supplier Name, Invoice Number, Invoice Date, Taxable Value, IGST, CGST, SGST, ITC Available, Type (invoice, credit note, debit note).</p>
      <input type="file" accept=".json,.csv,application/json,text/csv" onChange={pick} className="mt-3 block text-sm text-ink file:mr-3 file:h-9 file:rounded-lg file:border file:border-line file:bg-surface file:px-3 file:text-sm file:font-semibold" />
      {parsed ? (
        <div className="mt-3 text-sm">
          {parsed.problems.map((p) => <p key={p} className="text-danger">{p}</p>)}
          {parsed.rows.length ? <p className="text-ink">Found {parsed.rows.length} rows ({parsed.rows.filter((r) => r.type === "invoice").length} invoices, {parsed.rows.filter((r) => r.type !== "invoice").length} notes).</p> : null}
          {mismatch ? <p className="mt-1 text-warning">This file is for {parsed.period}, but you are on {month}. Check the month before uploading.</p> : null}
          {parsed.rows.length ? <button type="button" className={`${primaryBtn} mt-3`} disabled={busy} onClick={send}>{busy ? "Uploading…" : "Upload and match"}</button> : null}
        </div>
      ) : null}
      {err ? <p className="mt-3 text-sm text-danger">{err}</p> : null}
    </div>
  );
}
