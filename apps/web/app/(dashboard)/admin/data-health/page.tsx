import { createClient } from "@/lib/supabase/server";

type Row = { module: string; check_name: string; status: string; bad: number; total: number; hint: string };

const TONE: Record<string, string> = {
  ok: "bg-success-tint text-success",
  warn: "bg-warning-tint text-warning",
  fail: "bg-danger-tint text-danger",
  error: "bg-danger-tint text-danger",
  empty: "bg-surface-sunken text-ink-faint",
};
const LABEL: Record<string, string> = { ok: "OK", warn: "Look", fail: "Wrong", error: "Error", empty: "No data" };

export default async function DataHealthPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("data_health");
  const rows: Row[] = (data ?? []).map((r: Record<string, unknown>) => ({
    module: String(r.module), check_name: String(r.check_name), status: String(r.status),
    bad: Number(r.bad), total: Number(r.total), hint: String(r.hint ?? ""),
  }));
  const count = (s: string) => rows.filter((r) => r.status === s).length;
  const modules = [...new Set(rows.map((r) => r.module))];

  return (
    <div className="px-4 md:px-8 py-6">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Data Health</h1>
      <p className="mt-1 text-sm text-ink-muted">
        Checks that orders, invoices, stock, settlements, purchases, payroll and the books agree with each other. &quot;No data&quot; means that area has nothing in it yet.
      </p>
      {error ? <p className="mt-3 text-sm text-danger">Could not run the checks: {error.message}</p> : null}

      <div className="mt-3 flex flex-wrap gap-2 text-xs">
        {(["fail", "error", "warn", "ok", "empty"] as const).map((s) => (
          <span key={s} className={`rounded-full px-3 py-1 font-medium ${TONE[s]}`}>{count(s)} {LABEL[s]}</span>
        ))}
      </div>

      <div className="mt-3 grid grid-cols-1 gap-3 lg:grid-cols-2">
        {modules.map((m) => {
          const list = rows.filter((r) => r.module === m);
          return (
            <section key={m} className="border border-line bg-surface">
              <h2 className="border-b border-line px-3 py-1.5 text-sm font-semibold text-ink">{m}</h2>
              <ul className="divide-y divide-line">
                {list.map((r) => (
                  <li key={r.check_name} className="flex items-start gap-2 px-3 py-1.5 text-sm">
                    <span className={`mt-0.5 w-16 shrink-0 rounded px-1.5 py-0.5 text-center text-[11px] font-medium ${TONE[r.status]}`}>{LABEL[r.status]}</span>
                    <div className="min-w-0 flex-1">
                      <div className="text-ink">{r.check_name}</div>
                      {r.status === "warn" || r.status === "fail" || r.status === "error" ? (
                        <div className="text-xs text-ink-muted">{r.hint}</div>
                      ) : null}
                    </div>
                    <span className="shrink-0 font-data text-xs text-ink-muted">
                      {r.status === "empty" ? "—" : `${r.bad} of ${r.total}`}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          );
        })}
      </div>
    </div>
  );
}
