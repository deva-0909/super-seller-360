// The database returns at most 1000 rows per request. Any screen that adds up
// figures must read every row, otherwise totals are silently short.
// fetchAll() reads page after page until the table is exhausted.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Q = { range: (from: number, to: number) => PromiseLike<{ data: any[] | null; error: { message: string } | null }> };

export async function fetchAll<T = Record<string, unknown>>(
  build: () => Q,
  opts: { pageSize?: number; maxRows?: number } = {},
): Promise<{ data: T[]; error: string | null; truncated: boolean }> {
  const size = opts.pageSize ?? 1000;
  const max = opts.maxRows ?? 200000;
  const out: T[] = [];
  for (let from = 0; from < max; from += size) {
    const { data, error } = await build().range(from, from + size - 1);
    if (error) return { data: out, error: error.message, truncated: false };
    const rows = (data ?? []) as T[];
    out.push(...rows);
    if (rows.length < size) return { data: out, error: null, truncated: false };
  }
  return { data: out, error: null, truncated: true };
}
