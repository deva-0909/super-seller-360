import Link from "next/link";

/** Shared pieces of the two statutory-style reports (Balance Sheet, Profit and Loss): a group line that opens to show its ledgers. */

export type TallyRow = { id: string; name: string; amount: number };
export type TallyGroupData = { key: string; label: string; total: number; rows: TallyRow[] };

const money = (n: number) =>
  `₹${(Math.round(n * 100) / 100).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** Groups ledger rows by their account group, drops zero ledgers, keeps the order they arrive in. */
export function groupRows(rows: { id: string; name: string; group: string; amount: number }[]): TallyGroupData[] {
  const map = new Map<string, TallyGroupData>();
  for (const r of rows) {
    if (Math.abs(r.amount) < 0.005) continue;
    const g = map.get(r.group) ?? { key: r.group, label: r.group, total: 0, rows: [] };
    g.rows.push({ id: r.id, name: r.name, amount: r.amount });
    g.total += r.amount;
    map.set(r.group, g);
  }
  return [...map.values()];
}

/** One group line. Uses the browser's own open/close, so it works without any script; `open` expands it from the start. */
export function TallyGroup({ g, open, ledgerHref }: { g: TallyGroupData; open: boolean; ledgerHref?: (id: string) => string }) {
  return (
    <details open={open} className="group">
      <summary className="flex cursor-pointer list-none items-center justify-between rounded px-1 py-0.5 text-sm hover:bg-surface-sunken">
        <span className="flex items-center gap-1.5 font-medium text-ink">
          <span aria-hidden className="inline-block w-3 text-ink-faint transition-transform group-open:rotate-90">›</span>
          {g.label}
        </span>
        <span className="font-data text-ink">{money(g.total)}</span>
      </summary>
      <div className="pb-1">
        {g.rows.map((r) => (
          <div key={r.id} className="flex justify-between py-px pl-6 pr-1 text-xs text-ink-muted">
            {ledgerHref ? (
              <Link href={ledgerHref(r.id)} className="hover:text-accent hover:underline">{r.name}</Link>
            ) : (
              <span>{r.name}</span>
            )}
            <span className="font-data">{money(r.amount)}</span>
          </div>
        ))}
      </div>
    </details>
  );
}

export function TallyTotal({ label, amount, strong, tone }: { label: string; amount: number; strong?: boolean; tone?: "good" | "bad" }) {
  const colour = tone === "good" ? "text-success" : tone === "bad" ? "text-danger" : "text-ink";
  return (
    <div className={`flex justify-between border-t ${strong ? "border-line-strong border-t-2 text-base" : "border-line"} mt-1 px-1 pt-1 text-sm font-semibold ${colour}`}>
      <span>{label}</span>
      <span className="font-data">{money(amount)}</span>
    </div>
  );
}

export { money };
