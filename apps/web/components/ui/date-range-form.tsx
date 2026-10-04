/** Plain GET form (works without JavaScript): sends ?from=&to= back to the same page. */
export function DateRangeForm({ from, to, extra }: { from: string; to: string; extra?: Record<string, string> }) {
  return (
    <form method="get" className="mt-4 flex flex-wrap items-end gap-3">
      {Object.entries(extra ?? {}).map(([k, v]) => (
        <input key={k} type="hidden" name={k} value={v} />
      ))}
      <label className="flex flex-col gap-1 text-xs text-ink-muted">
        From
        <input type="date" name="from" defaultValue={from} className="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink" />
      </label>
      <label className="flex flex-col gap-1 text-xs text-ink-muted">
        To
        <input type="date" name="to" defaultValue={to} className="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink" />
      </label>
      <button type="submit" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">
        Show
      </button>
    </form>
  );
}
