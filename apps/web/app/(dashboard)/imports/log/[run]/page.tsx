import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { KINDS } from "@/lib/importer/kinds";

export default async function ImportLogPage({ params }: { params: Promise<{ run: string }> }) {
  const { run } = await params;
  const supabase = await createClient();
  const { data: r } = await supabase.from("import_runs").select("*").eq("run_id", run).maybeSingle();
  if (!r) notFound();
  const [{ data: rows }, { data: who }] = await Promise.all([
    supabase.from("import_run_rows").select("row_no, status, action, message").eq("run_id", run).order("row_no").limit(5000),
    supabase.from("user_profiles").select("name").eq("user_id", r.uploaded_by).maybeSingle(),
  ]);
  let fileUrl: string | null = null;
  if (r.file_path) {
    const { data } = await supabase.storage.from("imports").createSignedUrl(r.file_path, 300, { download: r.file_name ?? true });
    fileUrl = data?.signedUrl ?? null;
  }
  const pill: Record<string, string> = {
    ok: "text-success bg-success-tint border-success/30", warning: "text-warning bg-warning-tint border-warning/30", error: "text-danger bg-danger-tint border-danger/30",
  };
  return (
    <div className="mx-auto max-w-4xl px-4 md:px-8 py-8">
      <Link href="/imports" className="text-sm text-ink-muted hover:text-ink">← Excel uploads</Link>
      <h1 className="mt-4 text-lg font-semibold tracking-tight text-ink">{KINDS[r.kind]?.title ?? r.kind}</h1>
      <p className="mt-1 text-sm text-ink-muted">
        {r.file_name} · {who?.name ?? "unknown"} · {new Date(r.uploaded_at).toLocaleString()}
      </p>
      <p className="mt-3 text-sm text-ink">
        {r.total_rows} rows: added {r.added}, updated {r.updated}, unchanged {r.unchanged}, rejected {r.rejected} ({r.warnings} with warnings).
      </p>
      {fileUrl ? <a href={fileUrl} className="mt-2 inline-block text-sm text-accent hover:underline">Download the original file</a> : null}
      <div className="mt-6 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-2 font-medium">Row</th><th className="px-4 py-2 font-medium">Result</th>
              <th className="px-4 py-2 font-medium">What happened</th><th className="px-4 py-2 font-medium">Why</th>
            </tr>
          </thead>
          <tbody>
            {(rows ?? []).map((x) => (
              <tr key={x.row_no} className="border-t border-line">
                <td className="px-4 py-2 font-data text-ink-muted">{x.row_no || "File"}</td>
                <td className="px-4 py-2"><span className={`inline-flex rounded-full border px-2.5 py-0.5 text-xs font-semibold ${pill[x.status]}`}>{x.status === "ok" ? "OK" : x.status === "warning" ? "Warning" : "Error"}</span></td>
                <td className="px-4 py-2 text-ink-muted">{x.action}</td>
                <td className="px-4 py-2 text-ink">{x.message}</td>
              </tr>
            ))}
            {!rows?.length ? <tr><td colSpan={4} className="px-4 py-6 text-center text-sm text-ink-muted">All rows were OK and unchanged.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
