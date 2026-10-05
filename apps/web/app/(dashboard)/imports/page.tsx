import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { KINDS, KIND_ORDER } from "@/lib/importer/kinds";

export default async function ImportsPage() {
  const supabase = await createClient();
  const can = await Promise.all(KIND_ORDER.map(async (k) => [k, (await supabase.rpc("import_can", { p_kind: k })).data === true] as const));
  const allowed = new Set(can.filter(([, ok]) => ok).map(([k]) => k));

  const { data: runs } = await supabase
    .from("import_runs")
    .select("run_id, kind, file_name, uploaded_by, uploaded_at, total_rows, added, updated, unchanged, rejected")
    .order("uploaded_at", { ascending: false })
    .limit(50);
  const ids = [...new Set((runs ?? []).map((r) => r.uploaded_by))];
  const { data: people } = ids.length ? await supabase.from("user_profiles").select("user_id, name").in("user_id", ids) : { data: [] };
  const who = new Map((people ?? []).map((p) => [p.user_id, p.name]));

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Excel uploads</h1>
      <p className="mt-1 text-sm text-ink-muted">
        Every upload works the same way: download the template, upload your .xlsx or .csv, check the preview, then import. Re-uploading a corrected file never creates duplicates.
        You see the uploads your role may use.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        {KIND_ORDER.map((k) => {
          const c = KINDS[k];
          const ok = allowed.has(k);
          return (
            <div key={k} className="border border-line bg-surface p-4">
              <h2 className="text-sm font-semibold text-ink">{c.title}</h2>
              <p className="mt-1 text-xs text-ink-muted">{c.intro}</p>
              <p className="mt-2 text-xs text-ink-faint">For: {c.roles.join(", ")}</p>
              {ok ? (
                <div className="mt-3 flex gap-4 text-xs">
                  <Link href={`/imports/${k}`} className="font-medium text-accent hover:underline">Upload a file</Link>
                  <a href={`/api/import-template/${k}`} className="text-accent hover:underline">Download the template</a>
                </div>
              ) : (
                <p className="mt-3 text-xs text-ink-muted">Not available to your role.</p>
              )}
            </div>
          );
        })}
      </div>

      <h2 className="mt-10 text-sm font-semibold text-ink">Import log</h2>
      <div className="mt-3 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">When</th>
              <th className="px-4 py-3 font-medium">Upload</th>
              <th className="px-4 py-3 font-medium">File</th>
              <th className="px-4 py-3 font-medium">By</th>
              <th className="px-4 py-3 font-medium text-right">Added</th>
              <th className="px-4 py-3 font-medium text-right">Updated</th>
              <th className="px-4 py-3 font-medium text-right">Rejected</th>
              <th className="px-4 py-3 font-medium"></th>
            </tr>
          </thead>
          <tbody>
            {(runs ?? []).map((r, i) => (
              <tr key={r.run_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-2 font-data text-ink-muted">{new Date(r.uploaded_at).toLocaleString()}</td>
                <td className="px-4 py-2 text-ink">{KINDS[r.kind]?.title.replace(/^Upload |^Import /, "") ?? r.kind}</td>
                <td className="px-4 py-2 text-ink-muted">{r.file_name}</td>
                <td className="px-4 py-2 text-ink-muted">{who.get(r.uploaded_by) ?? "—"}</td>
                <td className="px-4 py-2 text-right font-data">{r.added}</td>
                <td className="px-4 py-2 text-right font-data">{r.updated}</td>
                <td className="px-4 py-2 text-right font-data">{r.rejected}</td>
                <td className="px-4 py-2"><Link href={`/imports/log/${r.run_id}`} className="text-xs text-accent hover:underline">Details</Link></td>
              </tr>
            ))}
            {!runs?.length ? <tr><td colSpan={8} className="px-4 py-8 text-center text-sm text-ink-muted">No uploads yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
