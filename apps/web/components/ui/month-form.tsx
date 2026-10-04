/** Plain GET form: sends ?month=YYYY-MM back to the same page. */
export function MonthForm({ month }: { month: string }) {
  return (
    <form method="get" className="mt-4 flex flex-wrap items-end gap-3">
      <label className="flex flex-col gap-1 text-xs text-ink-muted">
        Month
        <input type="month" name="month" defaultValue={month} className="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink" />
      </label>
      <button type="submit" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Show</button>
    </form>
  );
}
