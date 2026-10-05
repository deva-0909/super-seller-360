import { CsvButton } from "@/components/ui/csv-button";

export type Col = { key: string; label: string; align?: "right"; money?: boolean };

const fmt = (v: unknown, money?: boolean) => {
  if (v === null || v === undefined || v === "") return "—";
  if (money) {
    const n = Number(v);
    return n === 0 ? "—" : n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  return String(v);
};

/** One GSTR-1 section: a table with a download button that exports exactly what is shown. */
export function SectionTable({ title, note, cols, rows, csvName }: {
  title: string; note?: string; cols: Col[]; rows: Record<string, unknown>[]; csvName: string;
}) {
  const totals = cols.filter((c) => c.money).map((c) => ({ key: c.key, v: rows.reduce((s, r) => s + Number(r[c.key] ?? 0), 0) }));
  const csv: (string | number | null)[][] = [
    cols.map((c) => c.label),
    ...rows.map((r) => cols.map((c) => (c.money ? Number(r[c.key] ?? 0) : ((r[c.key] as string | number | null) ?? ""))))
  ];
  return (
    <section className="mt-8">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-sm font-semibold text-ink">{title} <span className="font-normal text-ink-muted">· {rows.length} row{rows.length === 1 ? "" : "s"}</span></h2>
          {note ? <p className="mt-0.5 text-xs text-ink-muted">{note}</p> : null}
        </div>
        {rows.length ? <CsvButton rows={csv} filename={csvName} label="Download CSV" /> : null}
      </div>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              {cols.map((c) => <th key={c.key} className={`px-4 py-3 font-medium ${c.align === "right" || c.money ? "text-right" : ""}`}>{c.label}</th>)}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                {cols.map((c) => <td key={c.key} className={`px-4 py-2.5 ${c.money ? "text-right font-data text-ink" : "text-ink-muted"}`}>{fmt(r[c.key], c.money)}</td>)}
              </tr>
            ))}
            {!rows.length ? <tr><td colSpan={cols.length} className="px-4 py-6 text-center text-sm text-ink-muted">Nothing in this month.</td></tr> : null}
          </tbody>
          {rows.length && totals.length ? (
            <tfoot>
              <tr className="border-t border-line-strong text-sm font-medium">
                {cols.map((c, i) => {
                  const t = totals.find((x) => x.key === c.key);
                  return <td key={c.key} className={`px-4 py-2.5 ${t ? "text-right font-data text-ink" : ""}`}>{t ? fmt(t.v, true) : i === 0 ? "Total" : ""}</td>;
                })}
              </tr>
            </tfoot>
          ) : null}
        </table>
      </div>
    </section>
  );
}
